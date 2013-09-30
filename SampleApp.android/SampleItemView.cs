
using Android.App;
using Android.OS;
using MvvmQuickCross;
using SampleApp.Shared.ViewModels;
using SampleApp.Shared;

namespace SampleApp
{
    [Activity(Label = "SampleItem")]
    public class SampleItemView : ActivityViewBase<SampleItemViewModel>
    {
        protected override void OnCreate(Bundle bundle)
        {
            base.OnCreate(bundle);
            SetContentView(Resource.Layout.SampleItemView);
            Initialize(FindViewById(Resource.Id.SampleItemView), SampleAppApplication.Instance.SampleItemViewModel);
        }
    }
}