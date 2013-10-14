﻿namespace Twitter.Shared
{
    public interface ITwitterNavigator
    {
        void NavigateToMainView(object navigationContext);

        /* TODO: For each view, add a method to navigate to that view with a signature like this:
        void NavigateTo_VIEWNAME_View(object navigationContext);
         * Note that the New-View command adds the above code automatically (see http://github.com/MacawNL/MvvmQuickCross#new-view). */
    }
}
